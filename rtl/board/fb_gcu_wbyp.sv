// SPDX-License-Identifier: GPL-3.0-or-later
//
// [Firebeat] bm3: VRAM words written to a GCU port go past fb_gcu's queue, so that a display-list
// rewrite is not held behind the objects still drawing (HACKS, "GCU word bypass").
//
// Sits between fb_gcu_shell's queue pushes and fb_gcu. A word entry ({2'd0, index, word}) goes into
// a FIFO of 512; a writer gathers consecutive words into one burst of up to 64 beats and writes it on
// the engine's DDR3 port, taking the port only when the engine offers nothing. A command entry is
// held here until every word pushed before it is on the port, then enters the engine's queue; while
// it is held the shell takes no port writes (s_ready low), so no word overtakes it. Words pushed after
// a command may reach VRAM before the engine has finished that command: that is the relaxation.
//
// s_idle is the engine's idle with the FIFO, the writer and the held command empty: the shell's VRAM
// reads, frame-register writes and gcu_idle wait for it.

module fb_gcu_wbyp #(
    parameter logic [31:0] VBASE = 32'h3000_0000
) (
    input  logic         clk,
    input  logic         reset,

    // the shell's side, as fb_gcu's queue
    input  logic         s_push,
    input  logic [129:0] s_d,
    output logic         s_ready,
    output logic         s_idle,

    // fb_gcu's queue
    output logic         e_push,
    output logic [129:0] e_d,
    input  logic         e_ready,
    input  logic         e_idle,

    // fb_gcu's DDR3 master in, the shared one out
    input  logic         e_read,
    input  logic         e_write,
    input  logic [31:0]  e_addr,
    input  logic [10:0]  e_burst,
    input  logic [3:0]   e_be,
    input  logic [31:0]  e_wdata,
    input  logic [3:0]   e_be_hi,
    input  logic [31:0]  e_wdata_hi,
    output logic         e_waitn,

    output logic         m_read,
    output logic         m_write,
    output logic [31:0]  m_addr,
    output logic [10:0]  m_burst,
    output logic [3:0]   m_be,
    output logic [31:0]  m_wdata,
    output logic [3:0]   m_be_hi,
    output logic [31:0]  m_wdata_hi,
    input  logic         m_waitn
);

// ------------------------------------------------------------------------------------------
// word FIFO: {index[22:0], word}
// ------------------------------------------------------------------------------------------

logic [54:0] wf_mem [512];
logic [9:0]  wf_wp, wf_rp;
logic [54:0] wf_q;
logic        wf_rd;
wire  [9:0]  wf_cnt = wf_wp - wf_rp;
wire         s_word = s_push && s_d[129:128] == 2'd0;

always_ff @(posedge clk) begin
    if (s_word) begin
        wf_mem[wf_wp[8:0]] <= s_d[54:0];
        wf_wp <= wf_wp + 10'd1;
    end
    wf_q <= wf_mem[wf_rp[8:0]];
    if (wf_rd) begin
        wf_rp <= wf_rp + 10'd1;
    end
    if (reset) begin
        wf_wp <= '0;
        wf_rp <= '0;
    end
end

// ------------------------------------------------------------------------------------------
// the held command
// ------------------------------------------------------------------------------------------

logic         pc_v;
logic [129:0] pc_d;

// ------------------------------------------------------------------------------------------
// writer: words gathered into the beats from st_b0 (offsets 0-63), then written as one burst
// ------------------------------------------------------------------------------------------

typedef enum logic [2:0] { W_IDLE, W_POP, W_DEC, W_FL, W_PRIME, W_REQ, W_BURST } ws_t;
ws_t ws;

logic [31:0] lo_mem [64], hi_mem [64];
logic [31:0] lo_q, hi_q;
logic [63:0] lo_v, hi_v;                // the words written in each beat
logic        st_any;
logic [21:0] st_b0;
logic [5:0]  st_lo, st_hi;              // the first and last beats written
logic [3:0]  tmo;                       // clocks with the FIFO empty and beats gathered
logic        hw_v;                      // a word popped outside the beats, decoded after the burst
logic [54:0] hw;
wire  [54:0] dw = hw_v ? hw : wf_q;

logic        wo;                        // the writer has the port
logic        b_kill;                    // reset during a burst: its remaining beats write nothing
logic [5:0]  b_o;                       // the beat offered
logic [6:0]  b_left;
logic [21:0] b_b0;
logic [6:0]  b_n;

wire b_acc = wo && ws == W_BURST && m_waitn;
wire [5:0] b_ra = b_acc ? b_o + 6'd1 : b_o;

always_ff @(posedge clk) begin
    lo_q <= lo_mem[b_ra];
    hi_q <= hi_mem[b_ra];
end

wire drained = wf_cnt == 10'd0 && !s_word && ws == W_IDLE && !st_any && !hw_v;

always_ff @(posedge clk) begin
    wf_rd <= 1'b0;
    e_push <= 1'b0;

    // a command: held until the words before it are written and the engine's queue has room
    if (s_push && s_d[129:128] != 2'd0) begin
        pc_v <= 1'b1;
        pc_d <= s_d;
    end
    if (pc_v && drained && e_ready && !e_push) begin
        e_push <= 1'b1;
        e_d <= pc_d;
        pc_v <= 1'b0;
    end

    case (ws)
    W_IDLE:
        if (wf_cnt != 10'd0) begin
            wf_rd <= 1'b1;
            ws <= W_POP;
        end else if (st_any && (tmo == 4'd15 || pc_v)) begin
            ws <= W_FL;
        end else if (st_any) begin
            tmo <= tmo + 4'd1;
        end
    W_POP: ws <= W_DEC;                 // wf_q holds the word next clock
    W_DEC: begin
        logic [21:0] off;
        off = dw[54:33] - st_b0;
        hw_v <= 1'b0;
        if (!st_any || off < 22'd64) begin
            logic [5:0] o;
            o = st_any ? off[5:0] : 6'd0;
            if (!st_any) begin
                st_b0 <= dw[54:33];
            end
            if (dw[32]) begin
                hi_mem[o] <= dw[31:0];
                hi_v[o] <= 1'b1;
            end else begin
                lo_mem[o] <= dw[31:0];
                lo_v[o] <= 1'b1;
            end
            if (!st_any || o < st_lo) begin
                st_lo <= o;
            end
            if (!st_any || o > st_hi) begin
                st_hi <= o;
            end
            st_any <= 1'b1;
            tmo <= '0;
            if (wf_cnt != 10'd0) begin
                wf_rd <= 1'b1;
                ws <= W_POP;
            end else begin
                ws <= W_IDLE;
            end
        end else begin
            hw <= dw;
            hw_v <= 1'b1;
            ws <= W_FL;
        end
    end
    W_FL: begin
        b_b0 <= st_b0 + 22'(st_lo);
        b_n <= 7'(st_hi - st_lo) + 7'd1;
        b_left <= 7'(st_hi - st_lo) + 7'd1;
        b_o <= st_lo;
        ws <= W_PRIME;
    end
    W_PRIME: ws <= W_REQ;               // lo_q / hi_q hold beat b_o
    W_REQ: if (wo) ws <= W_BURST;
    W_BURST:
        if (m_waitn) begin
            b_o <= b_o + 6'd1;
            b_left <= b_left - 7'd1;
            if (b_left == 7'd1) begin
                st_any <= 1'b0;
                lo_v <= '0;
                hi_v <= '0;
                b_kill <= 1'b0;
                tmo <= '0;
                ws <= hw_v ? W_DEC : W_IDLE;
            end
        end
    default: ws <= W_IDLE;
    endcase

    // the port: taken when the engine offers nothing, given back after the burst's last beat
    if (!wo && ws == W_REQ && !e_read && !e_write) begin
        wo <= 1'b1;
    end
    if (b_acc && b_left == 7'd1) begin
        wo <= 1'b0;
    end

    if (reset) begin
        pc_v <= 1'b0;
        e_push <= 1'b0;
        hw_v <= 1'b0;
        // a burst on the port is finished, writing nothing (hornet_ddr3 cannot cancel it)
        if (ws == W_BURST && !(b_acc && b_left == 7'd1)) begin
            b_kill <= 1'b1;
        end else begin
            ws <= W_IDLE;
            wo <= 1'b0;
            st_any <= 1'b0;
            lo_v <= '0;
            hi_v <= '0;
            tmo <= '0;
        end
    end
end

wire        b_on = wo && ws == W_BURST;

assign m_read     = wo ? 1'b0 : e_read;
assign m_write    = wo ? b_on : e_write;
assign m_addr     = wo ? VBASE + {7'd0, b_b0, 3'd0} : e_addr;
assign m_burst    = wo ? {3'd0, b_n, 1'b0} : e_burst;
assign m_wdata    = wo ? lo_q : e_wdata;
assign m_wdata_hi = wo ? hi_q : e_wdata_hi;
assign m_be       = wo ? ((lo_v[b_o] && !b_kill) ? 4'hF : 4'h0) : e_be;
assign m_be_hi    = wo ? ((hi_v[b_o] && !b_kill) ? 4'hF : 4'h0) : e_be_hi;
assign e_waitn    = wo ? 1'b0 : m_waitn;

assign s_ready = !pc_v && wf_cnt < 10'd500;
assign s_idle  = e_idle && drained && !pc_v;

endmodule
