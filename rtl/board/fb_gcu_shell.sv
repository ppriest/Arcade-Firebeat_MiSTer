// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 2's K057714 GCU: its registers and VRAM ports as MAME's k057714.cpp read and write them,
// without drawing (Phase 3 executes the commands collected here).
//
// Registers (0x7E800000-0x7E8000FF, 32-bit with byte enables): 0x00-0x08 the CRTC, 0x10 IRQ control
// (high half) and layer select (low), 0x14/0x18 alphas, 0x1C media bus, 0x20-0x2C origins, 0x30-0x3C
// sizes, 0x40-0x4C bases, 0x54/0x58 external FIFO, 0x5C VRAM read address, 0x60/0x64 write port
// addresses, 0x68 port modes, 0x6C, 0x70/0x74 the write ports. A port write in a mode with bit 8 set
// collects a command word (cmd_v with the four when the fourth arrives); otherwise it writes a VRAM
// word at the port's address, which then advances. Addresses written are byte addresses of 16-bit
// pixels: the 32-bit word index is the value / 2 (& 0xFFFFFF first).
//
// Reads: 0x80-0xFC the VRAM words from the read address on; 0x78 status: 0xFFFF0005 as MAME's,
// except that bits 1:0 (port 0) or 3:2 (port 1), the ready fields the code polls (FFF863D8,
// 80042A88), read 0 while a DMA transfer feeds that port (fb_board, dma_hold low); anything else
// 0xFFFFFFFF.
//
// vblank: at its start the IRQ rises if IRQ control bit 0 is set; a write of IRQ control with
// bit 0 clear drops it.
//
// VRAM: a word port (index 0 to 8M-1) on DDR3. Writes go through a queue so that the CPU and the
// DMA are not held for DDR3; a read waits for the queue to empty.

module fb_gcu_shell (
    input  logic        clk,
    input  logic        reset,

    input  logic        req,            // held until ack
    input  logic        we,
    input  logic [7:0]  addr,           // byte offset, word aligned
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic        ack,
    output logic [31:0] rdata,

    input  logic        dg_we,          // the DMA's direct path: a word to port dg_port's FIFO
    input  logic        dg_port,
    input  logic [31:0] dg_data,
    output logic        dg_ready,

    input  logic        vblank,
    input  logic        busy0,          // a DMA transfer feeds port 0 / 1 (status bits 1:0 / 3:2 read 0)
    input  logic        busy1,
    output logic        irq,

    output logic        cmd_v,          // a command's four words (Phase 3: executed)
    output logic        cmd_port,
    output logic [127:0] cmd,

    output logic        v_req,
    output logic        v_we,
    output logic [22:0] v_addr,         // 32-bit word index
    output logic [31:0] v_wdata,
    input  logic        v_ack,
    input  logic [31:0] v_rdata,

    output logic [31:0] crtc [3],       // registers 0x00-0x08 as written (Phase 4 decodes them)
    output logic [15:0] ctrl_lo         // register 0x10's low half, the layer select
);

logic [31:0] crtc_r [3];
logic [15:0] layer;
logic [23:0] rd_addr, p0_addr, p1_addr;
logic [15:0] mode0, mode1, irqctrl;
logic [31:0] c0 [4], c1 [4];
logic [1:0]  c0n, c1n;

wire [31:0] mask = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};

// the write queue: {index, word}
localparam int QW = 6;
logic [54:0] q [1 << QW];
logic [QW:0] q_wp, q_rp;
wire         q_empty = q_wp == q_rp;
wire         q_full  = q_wp - q_rp == (QW+1)'(1 << QW);
logic        q_push;
logic [54:0] q_in;
wire  [54:0] q_head = q[q_rp[QW-1:0]];  // read combinationally: the head is valid as soon as it is pushed
always_ff @(posedge clk) if (q_push) q[q_wp[QW-1:0]] <= q_in;

// a VRAM read in hand
logic        r_on;
logic [22:0] r_a;

assign v_req   = r_on ? q_empty : !q_empty;
assign v_we    = !r_on;
assign v_addr  = r_on ? r_a : q_head[54:32];
assign v_wdata = q_head[31:0];

assign dg_ready = !q_full && !q_push;

logic vb_q;
always_ff @(posedge clk) begin
    ack <= 1'b0;
    cmd_v <= 1'b0;
    q_push <= 1'b0;
    vb_q <= vblank;
    if (vblank && !vb_q && irqctrl[0]) irq <= 1'b1;
    if (v_req && v_we && v_ack) q_rp <= q_rp + 1'd1;
    if (q_push) q_wp <= q_wp + 1'd1;

    if (r_on && v_ack && !v_we) begin r_on <= 1'b0; rdata <= v_rdata; ack <= 1'b1; end

    if (req && !ack && !r_on) begin
        if (!we) begin
            if (addr[7]) begin r_on <= 1'b1; r_a <= 23'(rd_addr + {19'd0, addr[6:2]} - 24'd0); end
            else begin
                rdata <= (addr == 8'h78) ? {28'hFFFF_000, busy1 ? 2'b00 : 2'b01, busy0 ? 2'b00 : 2'b01} : 32'hFFFF_FFFF;
                ack <= 1'b1;
            end
        end else if ((addr == 8'h70 || addr == 8'h74) && !((addr == 8'h70 ? mode0[8] : mode1[8])) && (q_full || q_push)) ;
        else begin
            ack <= 1'b1;
            if (addr <= 8'h08) crtc_r[addr[3:2]] <= (crtc_r[addr[3:2]] & ~mask) | (wdata & mask);
            if (addr == 8'h10 && be[1:0] != 2'b00) layer <= wdata[15:0];
            case (addr)
            8'h10: if (be[3:2] != 2'b00) begin
                       if (!wdata[16]) irq <= 1'b0;
                       irqctrl <= wdata[31:16];
                   end
            8'h5C: rd_addr <= {1'b0, wdata[23:1]};
            8'h60: p0_addr <= {1'b0, wdata[23:1]};
            8'h64: p1_addr <= {1'b0, wdata[23:1]};
            8'h68: begin if (be[3:2] != 2'b00) mode0 <= wdata[31:16]; if (be[1:0] != 2'b00) mode1 <= wdata[15:0]; end
            8'h70:
                if (mode0[8]) begin
                    c0[c0n] <= wdata; c0n <= c0n + 2'd1;
                    if (c0n == 2'd3) begin cmd_v <= 1'b1; cmd_port <= 1'b0; cmd <= {c0[0], c0[1], c0[2], wdata}; end
                end else begin
                    q_push <= 1'b1; q_in <= {p0_addr[22:0], wdata}; p0_addr <= p0_addr + 24'd1;
                end
            8'h74:
                if (mode1[8]) begin
                    c1[c1n] <= wdata; c1n <= c1n + 2'd1;
                    if (c1n == 2'd3) begin cmd_v <= 1'b1; cmd_port <= 1'b1; cmd <= {c1[0], c1[1], c1[2], wdata}; end
                end else begin
                    q_push <= 1'b1; q_in <= {p1_addr[22:0], wdata}; p1_addr <= p1_addr + 24'd1;
                end
            default: ;
            endcase
        end
    end

    // the DMA's words, as writes of register 0x70 / 0x74 (the bus is idle meanwhile: the CPU is held)
    if (dg_we) begin
        if (!dg_port) begin
            if (mode0[8]) begin
                c0[c0n] <= dg_data; c0n <= c0n + 2'd1;
                if (c0n == 2'd3) begin cmd_v <= 1'b1; cmd_port <= 1'b0; cmd <= {c0[0], c0[1], c0[2], dg_data}; end
            end else begin q_push <= 1'b1; q_in <= {p0_addr[22:0], dg_data}; p0_addr <= p0_addr + 24'd1; end
        end else begin
            if (mode1[8]) begin
                c1[c1n] <= dg_data; c1n <= c1n + 2'd1;
                if (c1n == 2'd3) begin cmd_v <= 1'b1; cmd_port <= 1'b1; cmd <= {c1[0], c1[1], c1[2], dg_data}; end
            end else begin q_push <= 1'b1; q_in <= {p1_addr[22:0], dg_data}; p1_addr <= p1_addr + 24'd1; end
        end
    end

    if (reset) begin
        irq <= 1'b0; irqctrl <= 16'h0; mode0 <= 16'h0; mode1 <= 16'h0; c0n <= 2'd0; c1n <= 2'd0;
        q_wp <= '0; q_rp <= '0; r_on <= 1'b0; rd_addr <= '0; p0_addr <= '0; p1_addr <= '0;
    end
end

assign crtc[0] = crtc_r[0];
assign crtc[1] = crtc_r[1];
assign crtc[2] = crtc_r[2];
assign ctrl_lo = layer;

endmodule
